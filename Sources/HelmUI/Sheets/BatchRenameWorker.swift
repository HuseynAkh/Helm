// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-055 preview lifetime: one running calculation and at most one latest pending revision (B-010).
@MainActor final class BatchRenameWorker {
    private struct Request {
        let id: UUID
        let work: @Sendable () throws -> BatchRenameEvaluation
        let continuation: CheckedContinuation<BatchRenameEvaluation, Error>
    }
    private var active: (request: Request, task: Task<BatchRenameEvaluation, Error>)?
    private var pending: Request?

    func evaluate(_ work: @escaping @Sendable () throws -> BatchRenameEvaluation) async throws -> BatchRenameEvaluation {
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = Request(id: id, work: work, continuation: continuation)
                pending?.continuation.resume(throwing: CancellationError())
                pending = nil
                if let active {
                    active.task.cancel()
                    pending = request
                } else { start(request) }
            }
        }, onCancel: { Task { @MainActor in self.cancel(id) } })
    }

    func cancelAll() {
        active?.task.cancel()
        pending?.continuation.resume(throwing: CancellationError())
        pending = nil
    }

    private func cancel(_ id: UUID) {
        if active?.request.id == id { active?.task.cancel() }
        if pending?.id == id {
            pending?.continuation.resume(throwing: CancellationError()); pending = nil
        }
    }
    private func start(_ request: Request) {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try request.work()
            try Task.checkCancellation()
            return result
        }
        active = (request, task)
        Task {
            let result = await task.result
            guard active?.request.id == request.id else { return }
            active = nil
            request.continuation.resume(with: task.isCancelled ? .failure(CancellationError()) : result)
            if let next = pending { pending = nil; start(next) }
        }
    }
}
