import Foundation

/// Turns the lines of one streamed reply into events, and at the end into the turn's result.
public protocol AgentStreamReading: AnyObject {
    func feed(_ line: String) -> [AgentModelEvent]
    func finish() -> AgentTurnResult
}

/// One provider's request and reply shapes. Pure: a turn goes in and bytes come out, lines go in and events come
/// out. An adapter never sees an address, a key or a connection.
public protocol AgentWireAdapter: Sendable {
    func turnBody(_ input: AgentTurnInput, model: String) throws -> Data
    func structuredBody(_ ask: AgentStructuredAsk, model: String) throws -> Data
    /// The JSON a structured ask was answered with, taken out of the provider's reply. Where a server ignored the
    /// shape it was given, the first JSON object in its text is used.
    func structuredAnswer(from body: Data) throws -> Data
    func makeReader() -> any AgentStreamReading
    /// One user turn in the provider's own shape, with the tool results before the text.
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON]
    func failure(status: Int, body: Data) -> AgentFailure
}
