import Foundation

/// A tool as a model is told about it. The schema is the tool's own; each provider's adapter wraps it the way that
/// provider wants.
public struct AgentToolSpec: Hashable, Sendable {
    public let name: String, description: String
    public let schema: AgentJSON
    public init(name: String, description: String, schema: AgentJSON) {
        self.name = name; self.description = description; self.schema = schema
    }
}

/// A model's request to run a tool. An id repeated within one turn, or one longer than
/// `AgentLimits.callIDCharacters`, makes the whole turn unreadable.
public struct AgentToolCall: Hashable, Sendable {
    public let id: String, name: String
    /// The model's JSON, exactly as it came. Nothing has checked it yet.
    public let arguments: Data
    public init(id: String, name: String, arguments: Data) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// What a tool answered, on its way back to the model.
public struct AgentToolResult: Hashable, Sendable {
    public let callID: String, name: String
    /// JSON text that Helm built.
    public let json: String
    public let isError: Bool
    public init(callID: String, name: String, json: String, isError: Bool = false) {
        self.callID = callID; self.name = name; self.json = json; self.isError = isError
    }
}

/// Every way a request to a model can fail. The person sees a fixed line for each; a provider's own words are
/// never shown.
public enum AgentFailure: String, Error, Sendable, CaseIterable {
    case off, notReady, noKey, keyDenied, wrongKey, outOfCredit, rateLimited, overloaded, noSuchModel, noTools,
         badRequest, tooLarge, unreachable, notRunning, timedOut, unreadable, cancelled
}

/// Why a model's turn ended.
public enum AgentStop: Equatable, Sendable { case endTurn, toolUse, maxTokens, refusal, contentFilter, failed(AgentFailure) }

/// What one model turn is given.
public struct AgentTurnInput: Sendable {
    public var system: String
    public var tools: [AgentToolSpec]
    /// The conversation so far as the provider's own items. Items are only ever added at the end.
    public var history: [AgentJSON]
    public init(system: String, tools: [AgentToolSpec], history: [AgentJSON]) {
        self.system = system; self.tools = tools; self.history = history
    }
}

/// What one model turn came to.
public struct AgentTurnResult: Sendable {
    /// The provider's own items for this turn, to be added to the history unchanged.
    public var rawItems: [AgentJSON]
    public var calls: [AgentToolCall]
    public var stop: AgentStop
    public init(rawItems: [AgentJSON], calls: [AgentToolCall], stop: AgentStop) {
        self.rawItems = rawItems; self.calls = calls; self.stop = stop
    }
}

/// What arrives while a model answers. A tool's name is the model's own string: it is shown only when it is one of
/// `AgentToolCatalog.names`.
public enum AgentModelEvent: Sendable { case text(String), toolStarted(name: String), finished(AgentTurnResult) }

/// A question whose answer must be JSON of a given shape. No tools are offered with it.
public struct AgentStructuredAsk: Sendable {
    public var system: String, user: String, schemaName: String
    public var schema: AgentJSON
    public init(system: String, user: String, schemaName: String, schema: AgentJSON) {
        self.system = system; self.user = user; self.schemaName = schemaName; self.schema = schema
    }
}

/// A model a provider lists. The menu shows the id itself, never a display name a provider sent.
public struct AgentModelInfo: Hashable, Sendable, Identifiable {
    /// At most 128 characters from A-Z, a-z, 0-9 and `. _ : / -`.
    public let id: String
    /// Nil for an empty id and for one with any other character or more than 128 of them.
    public init?(id: String) {
        guard !id.isEmpty, id.unicodeScalars.count <= Self.idCharacters, id.unicodeScalars.allSatisfy(Self.isAllowed) else { return nil }
        self.id = id
    }
    /// The most models kept from one provider's list.
    public static let listCap = 500

    static let idCharacters = 128
    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || "._:/-".unicodeScalars.contains(scalar)
    }
}

/// A model, whichever provider it comes from.
public protocol AgentModelClient: Sendable {
    var providerName: String { get }
    /// Where requests go, as the person is told.
    var destination: String { get }
    var isLocal: Bool { get }
    /// One model turn. The last event is `.finished`. The stream throws only an `AgentFailure`.
    func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error>
    /// One user turn in the provider's own shape, with the tool results before the text.
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON]
    /// JSON in the shape the ask gives. No tools are sent.
    func structured(_ ask: AgentStructuredAsk) async throws -> Data
    func models() async throws -> [AgentModelInfo]
}

/// A client that holds a connection, which is let go when AI mode turns off or the provider changes.
public protocol AgentLiveClient: AgentModelClient {
    func shutdown() async
    /// Turns every request away from now on and forgets a cached key, before `shutdown()` gets its turn. It never
    /// waits, so AI mode turning off or the provider changing takes effect at once, even for a caller that still
    /// holds the client.
    func refuseRequests()
}

extension AgentLiveClient {
    public func refuseRequests() {}
}
