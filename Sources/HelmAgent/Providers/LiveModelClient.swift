import Foundation
import HelmCore

/// A model at a real provider: the provider's wire adapter joined to a transport made for that provider. The
/// adapter turns a turn into bytes and lines into events; the transport carries them. This class only passes them
/// between the two, maps what goes wrong to an `AgentFailure`, and refuses a turn whose calls can't be told apart.
public final class LiveModelClient: AgentLiveClient, @unchecked Sendable {
    public let providerName: String
    public let destination: String
    public let isLocal: Bool

    private let provider: AgentProviderID
    private let model: String
    private let transport: any AgentTransport
    private let adapter: any AgentWireAdapter

    public init(profile: AgentProviderProfile, model: String, transport: any AgentTransport) {
        providerName = profile.name
        destination = profile.destination
        isLocal = profile.isLocal
        provider = profile.id
        self.model = model
        self.transport = transport
        adapter = Self.adapter(for: profile.wire, profile: profile)
    }

    /// The adapter for a wire. A Chat Completions server on this Mac is sent no token ceiling.
    public static func adapter(for wire: AgentWire, profile: AgentProviderProfile) -> any AgentWireAdapter {
        switch wire {
        case .anthropicMessages: return AnthropicMessagesAdapter()
        case .openAIResponses: return OpenAIResponsesAdapter()
        case .chatCompletions: return ChatCompletionsAdapter(sendsMaxTokens: !profile.isLocal)
        }
    }

    // MARK: AgentModelClient

    /// One streamed turn. Text and the names of tools the model starts arrive as they come; the last event is the
    /// turn's result. A request that fails throws its `AgentFailure`; an error inside the stream finishes the turn
    /// as `.failed`. Stopping the stream cancels the request.
    public func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        let adapter = self.adapter, transport = self.transport, model = self.model, provider = self.provider
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let body = try adapter.turnBody(input, model: model)
                    let reader = adapter.makeReader()
                    for try await line in transport.stream(.chat, body: body) {
                        try Task.checkCancellation()
                        for event in reader.feed(line) { continuation.yield(event) }
                    }
                    try Task.checkCancellation()
                    continuation.yield(.finished(Self.checked(reader.finish())))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AgentErrorMapper.failure(of: error, provider: provider))
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    public func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] {
        adapter.userItems(text: text, toolResults: toolResults)
    }

    /// Asks for an answer of the ask's shape, with no tools. The request isn't streamed: its reply arrives as the
    /// lines of one JSON body, which are put back together before the answer is taken out.
    public func structured(_ ask: AgentStructuredAsk) async throws -> Data {
        do {
            let body = try adapter.structuredBody(ask, model: model)
            var lines: [String] = []
            for try await line in transport.stream(.chat, body: body) {
                try Task.checkCancellation()
                lines.append(line)
            }
            return try adapter.structuredAnswer(from: Data(lines.joined(separator: "\n").utf8))
        } catch {
            throw AgentErrorMapper.failure(of: error, provider: provider)
        }
    }

    /// The provider's models. A typed address whose models aren't where Chat Completions servers usually keep them
    /// is asked again under `/v1`; a key that was refused or a server that can't be reached is not asked twice.
    public func models() async throws -> [AgentModelInfo] {
        do {
            return try await models(on: .models)
        } catch let failure as AgentFailure {
            guard provider == .other, Self.triesAlternate.contains(failure) else { throw failure }
            if let listed = try? await models(on: .modelsAlternate) { return listed }
            throw failure
        }
    }

    public func shutdown() async {
        await transport.shutdown()
    }

    // MARK: Parts

    /// Failures after which a typed address's other model list is worth asking for.
    private static let triesAlternate: Set<AgentFailure> = [.noSuchModel, .badRequest, .unreadable]

    private func models(on route: AgentRoute) async throws -> [AgentModelInfo] {
        let reply: AgentHTTPReply
        do {
            reply = try await transport.fetch(route)
        } catch {
            throw AgentErrorMapper.failure(of: error, provider: provider)
        }
        guard (200...299).contains(reply.status) else {
            throw AgentErrorMapper.failure(status: reply.status, body: reply.body, provider: provider)
        }
        return try AgentModelLister.models(from: reply.body, provider: provider)
    }

    /// A turn as it may be handed on. Calls are kept only when the turn asks for tools. A turn whose call ids
    /// repeat, or one with an id longer than `AgentLimits.callIDCharacters`, can't have its results matched to its
    /// calls, so it is unreadable, and nothing of it is kept or run.
    static func checked(_ result: AgentTurnResult) -> AgentTurnResult {
        var ids: Set<String> = []
        for call in result.calls {
            guard call.id.count <= AgentLimits.callIDCharacters, ids.insert(call.id).inserted else {
                return AgentTurnResult(rawItems: [], calls: [], stop: .failed(.unreadable))
            }
        }
        guard result.stop == .toolUse else { return AgentTurnResult(rawItems: result.rawItems, calls: [], stop: result.stop) }
        return result
    }
}
