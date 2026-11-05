// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Owns one injected stream; cancellation invalidates admission before cancelling work (B-021, F-046).
/// No filesystem or native service is created. Hosts observe value snapshots explicitly.
public actor SearchSessionDriver {
    public typealias EventSource = @Sendable (SearchQuery) -> AsyncThrowingStream<SearchSessionEvent, Error>
    private let source: EventSource
    private var task: Task<Void, Never>?
    public private(set) var state: SearchSessionState
    public init(source: @escaping EventSource) { self.source = source; self.state = SearchSessionState() }
    public init(service: any SearchService) {
        self.state = SearchSessionState()
        self.source = { query in
            AsyncThrowingStream { continuation in
                let worker = Task {
                    do {
                        for try await event in service.search(query) {
                            try Task.checkCancellation()
                            continuation.yield(.search(event))
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in worker.cancel() }
            }
        }
    }
    deinit { task?.cancel() }
    @discardableResult
    public func start(_ query: SearchQuery) -> UUID? {
        guard !state.isShutdown else { return nil }
        task?.cancel(); task = nil
        guard let generation = state.start(query) else { return nil }
        do {
            let specification = try SearchQueryParser.compile(SearchRequest(query: query))
            guard !specification.clauses.isEmpty else {
                state.receive(.failed("Search requires at least one criterion"), generation: generation)
                return generation
            }
        } catch {
            state.receive(.failed(String(describing: error)), generation: generation)
            return generation
        }
        let source = self.source
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                for try await event in source(query) {
                    try Task.checkCancellation()
                    await self?.receive(event, generation: generation)
                }
                await self?.receive(.finished, generation: generation)
            } catch {
                await self?.receive(.failed(String(describing: error)), generation: generation)
            }
        }
        return generation
    }
    @discardableResult
    public func refresh() -> UUID? {
        guard let query = state.query else { return nil }
        return start(query)
    }
    public func cancel() { state.cancel(); task?.cancel(); task = nil }
    public func shutdown() { state.shutdown(); task?.cancel(); task = nil }
    private func receive(_ event: SearchSessionEvent, generation: UUID) {
        state.receive(event, generation: generation)
    }
}
