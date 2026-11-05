import Foundation

/// Main-actor change delivery replaces Combine in portable stores (F-027, F-030).
/// Subscriptions receive future sends only. Nested sends queue FIFO; cancellation takes effect immediately.
@MainActor public final class Broadcast<Value: Sendable> {
    public struct Token: Hashable, Sendable {
        public let rawValue: UUID
        public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    }
    private var handlers: [Token: @MainActor (Value) -> Void] = [:]
    private var order: [Token] = []
    private var pending: [Value] = []
    private var isSending: Bool = false
    public init() {}
    public func subscribe(_ handler: @escaping @MainActor (Value) -> Void) -> Token {
        let token = Token(); handlers[token] = handler; order.append(token); return token
    }
    public func cancel(_ token: Token) { handlers[token] = nil; order.removeAll { $0 == token } }
    public func send(_ value: Value) {
        pending.append(value)
        guard !isSending else { return }
        isSending = true
        var index: Int = 0
        while index < pending.count {
            let next = pending[index]; index += 1
            let recipients = order
            for token in recipients { handlers[token]?(next) }
        }
        pending.removeAll(keepingCapacity: true); isSending = false
    }
}
