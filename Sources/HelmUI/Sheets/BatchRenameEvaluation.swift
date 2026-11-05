// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// One immutable F-055 evaluation keeps redraws from repeating full planning (B-010).
struct BatchRenameEvaluation: Sendable {
    let revision: UUID
    let plan: BatchRenamePlan?
    let preview: [RenamePreview]
    let messages: [String]
    init(revision: UUID, plan: BatchRenamePlan?, messages: [String]) {
        self.revision = revision; self.plan = plan; self.messages = messages
        self.preview = Array((plan?.previews ?? []).prefix(20))
    }
    func executablePlan(for revision: UUID) -> BatchRenamePlan? {
        guard self.revision == revision, plan?.canExecute == true else { return nil }
        return plan
    }
}

/// Copies share immutable inputs until an edit replaces this cache. All mutable
/// storage is lock-protected; racing planners may compute, but only one result is cached.
final class BatchRenameEvaluationCache: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var stored: BatchRenameEvaluation?
    private var evaluations = 0
    init() {}
    var count: Int { lock.lock(); defer { lock.unlock() }; return evaluations }
    func value(_ create: () throws -> BatchRenameEvaluation) rethrows -> BatchRenameEvaluation {
        lock.lock()
        let cached = stored
        lock.unlock()
        if let cached { return cached }
        let result = try create()
        lock.lock(); defer { lock.unlock() }
        // Edits create a new cache identity. Never publish an evaluation for another revision.
        guard result.revision == id else { return result }
        if let stored { return stored }
        stored = result; evaluations += 1
        return result
    }
}
