// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Quit waits for operations before flushing; failures keep the app alive (F-001, F-068, B-105).
/// The host must block new operations and persistence edits until cancellation or termination.
public struct QuitCoordinator: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, waiting, flushing, failed, ready }
    public enum Effect: Equatable, Sendable { case none, waitForOperations, flushStores, terminate, cancelQuit }
    public private(set) var state: State = .running
    public init() {}
    public mutating func requestQuit(inFlightOperations: Int) -> Effect {
        guard state == .running || state == .failed else { return .none }
        if inFlightOperations > 0 { state = .waiting; return .waitForOperations }
        state = .flushing; return .flushStores
    }
    public mutating func operationsChanged(inFlightOperations: Int) -> Effect {
        guard state == .waiting, inFlightOperations <= 0 else { return .none }
        state = .flushing; return .flushStores
    }
    public mutating func flushCompleted(succeeded: Bool) -> Effect {
        guard state == .flushing else { return .none }
        state = succeeded ? .ready : .failed
        return succeeded ? .terminate : .none
    }
    public mutating func cancel() -> Effect {
        guard state == .waiting || state == .failed else { return .none }
        state = .running; return .cancelQuit
    }
}
