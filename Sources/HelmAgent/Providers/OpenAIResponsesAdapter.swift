import Foundation
import HelmCore

/// The Responses API, which OpenAI and Grok need for tool calls on their current models. A history item is one
/// input item: the person's message, each output item exactly as the model sent it (reasoning items included), and
/// a `function_call_output` for each call, keyed by its `call_id`.
///
/// Every body says `store: false`, so the provider keeps nothing, and asks for reasoning in its encrypted form so
/// that it can be sent back with the next turn. The instructions go with every request, since nothing is stored.
/// Never a sampling setting, a tool choice or an effort.
///
/// A request billed to a ChatGPT plan (`planUsage`) keeps to what plan use takes: every request is streamed, a
/// structured one too, no token ceiling is sent, and the tools are grouped in one namespace.
public struct OpenAIResponsesAdapter: AgentWireAdapter {
    /// The request is billed to the person's ChatGPT plan.
    public let planUsage: Bool

    public init(planUsage: Bool = false) { self.planUsage = planUsage }

    /// The namespace a plan request's tools are grouped in.
    static let toolNamespace = "helm"

    public func turnBody(_ input: AgentTurnInput, model: String) throws -> Data {
        try AgentWireParts.check(model: model)
        var body = common(model: model, instructions: input.system)
        body["input"] = .array(input.history)
        body["stream"] = .bool(true)
        if !input.tools.isEmpty {
            let tools = input.tools.map(Self.tool)
            body["tools"] = planUsage ? .array([Self.namespace(tools)]) : .array(tools)
        }
        return AgentJSON.object(body).data()
    }

    public func structuredBody(_ ask: AgentStructuredAsk, model: String) throws -> Data {
        try AgentWireParts.check(model: model)
        var body = common(model: model, instructions: ask.system)
        let content: AgentJSON = ask.pictures.isEmpty ? .string(ask.user) : .array(Self.inputText(ask.user) + Self.parts(ask.pictures))
        body["input"] = .array([.object(["role": .string("user"), "content": content])])
        body["text"] = .object(["format": .object(["type": .string("json_schema"), "name": .string(ask.schemaName),
                                                   "schema": ask.schema, "strict": .bool(true)])])
        if planUsage { body["stream"] = .bool(true) }
        return AgentJSON.object(body).data()
    }

    public func structuredAnswer(from body: Data) throws -> Data {
        let reply: AgentJSON
        if let whole = try? AgentJSON(data: body), case .object = whole {
            reply = whole
        } else {
            reply = try Self.completedResponse(inStream: body, planUsage: planUsage)
        }
        if let error = reply["error"], error != .null { throw streamFailure(reply) }
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

    public func makeReader() -> any AgentStreamReading { Reader(planUsage: planUsage) }

    /// The results first, each as a `function_call_output` keyed by its call's `call_id`, then one message with the
    /// results' pictures, each after its label, then the person's text. The wire has no error flag; a result that is
    /// an error says so in its own JSON.
    public func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] {
        var items: [AgentJSON] = toolResults.map { result in
            .object(["type": .string("function_call_output"), "call_id": .string(result.callID),
                     "output": .string(result.json)])
        }
        let pictures = AgentToolResult.labeledPictures(toolResults).flatMap { $0 }
        if !pictures.isEmpty {
            items.append(.object(["role": .string("user"),
                                  "content": .array(Self.inputText(AgentWireParts.picturesIntro) + Self.parts(pictures))]))
        }
        if let text, !text.isEmpty { items.append(.object(["role": .string("user"), "content": .string(text)])) }
        return items
    }

    public func failure(status: Int, body: Data) -> AgentFailure {
        planUsage ? AgentErrorMapper.chatGPTFailure(status: status, body: body)
            : AgentErrorMapper.failure(status: status, body: body, provider: .openAI)
    }

    /// What every request carries. Plan use takes no token ceiling.
    private func common(model: String, instructions: String) -> [String: AgentJSON] {
        var body: [String: AgentJSON] = [
            "model": .string(model),
            "store": .bool(false),
            "include": .array([.string("reasoning.encrypted_content")])
        ]
        if !planUsage { body["max_output_tokens"] = .number(Double(AgentWireParts.maxOutputTokens)) }
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        return body
    }

    private func streamFailure(_ value: AgentJSON) -> AgentFailure {
        planUsage ? AgentErrorMapper.chatGPTFailure(streamError: value) : AgentErrorMapper.failure(streamError: value)
    }

    /// The tools in one namespace, as a request billed to a ChatGPT plan must send them.
    private static func namespace(_ tools: [AgentJSON]) -> AgentJSON {
        .object(["type": .string("namespace"), "name": .string(toolNamespace),
                 "description": .string("Helm's tools for the folders the person gave it."), "tools": .array(tools)])
    }

    /// The response a streamed answer completed with. A failed or an incomplete one throws, and so does a stream that
    /// ends without completing.
    private static func completedResponse(inStream body: Data, planUsage: Bool) throws -> AgentJSON {
        for line in String(decoding: body, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            guard case .json(let event) = AgentWireParts.line(String(line)) else { continue }
            switch event["type"]?.stringValue {
            case "response.completed":
                guard let response = event["response"], case .object = response else { throw AgentFailure.unreadable }
                return response
            case "response.failed", "error":
                let value = event["response"] ?? event
                throw planUsage ? AgentErrorMapper.chatGPTFailure(streamError: value) : AgentErrorMapper.failure(streamError: value)
            case "response.incomplete":
                throw AgentFailure.tooLarge
            default:
                continue
            }
        }
        throw AgentFailure.unreadable
    }

    private static func tool(_ spec: AgentToolSpec) -> AgentJSON {
        .object(["type": .string("function"), "name": .string(spec.name), "description": .string(spec.description),
                 "parameters": spec.schema, "strict": .bool(true)])
    }

    /// Each picture after its label, at low detail, which is enough for a picture this small.
    private static func parts(_ pictures: [AgentAskPicture]) -> [AgentJSON] {
        pictures.flatMap { picture in
            inputText(picture.label) + [.object(["type": .string("input_image"),
                                                 "image_url": .string(AgentWireParts.dataURL(picture.image)),
                                                 "detail": .string("low")])]
        }
    }

    private static func inputText(_ text: String) -> [AgentJSON] {
        text.isEmpty ? [] : [.object(["type": .string("input_text"), "text": .string(text)])]
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

        private let planUsage: Bool
        private var items: [Int: AgentJSON] = [:]
        private var announced: Set<String> = []
        private var refused = false
        private var ending: Ending?
        private var broken = false

        init(planUsage: Bool = false) { self.planUsage = planUsage }

        /// A call's tool name, without the namespace a plan request grouped its tools in, should one come written in.
        private func toolName(_ item: AgentJSON) -> String {
            let name = item["name"]?.stringValue ?? ""
            let prefix = OpenAIResponsesAdapter.toolNamespace + "."
            return planUsage && name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        }

        private func streamFailure(_ value: AgentJSON) -> AgentFailure {
            planUsage ? AgentErrorMapper.chatGPTFailure(streamError: value) : AgentErrorMapper.failure(streamError: value)
        }

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
                    AgentToolCall(id: item["call_id"]?.stringValue ?? "", name: toolName(item),
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
                ending = conclusion(of: event["response"])
                return []
            case "response.incomplete":
                ending = .incomplete(reason: event["response"]?["incomplete_details"]?["reason"]?.stringValue)
                return []
            case "response.failed":
                ending = .failed(streamFailure(event["response"] ?? event))
                return []
            case "error":
                ending = .failed(streamFailure(event))
                return []
            default:
                // response.created, in_progress, argument fragments, and any event a later version adds.
                return []
            }
        }

        /// A completed response, unless its own status says otherwise.
        private func conclusion(of response: AgentJSON?) -> Ending {
            switch response?["status"]?.stringValue {
            case "incomplete": return .incomplete(reason: response?["incomplete_details"]?["reason"]?.stringValue)
            case "failed", "cancelled": return .failed(streamFailure(response ?? .null))
            default: return .completed(output: response?["output"]?.arrayValue ?? [])
            }
        }

        /// The first word that a call has started, once for each call.
        private func announce(_ item: AgentJSON?) -> [AgentModelEvent] {
            guard let item, item["type"]?.stringValue == "function_call" else { return [] }
            let key = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? ""
            guard announced.insert(key).inserted else { return [] }
            return [.toolStarted(name: toolName(item))]
        }

        private static func holdsRefusal(_ item: AgentJSON) -> Bool {
            guard item["type"]?.stringValue == "message" else { return false }
            return (item["content"]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "refusal" }
        }
    }
}
