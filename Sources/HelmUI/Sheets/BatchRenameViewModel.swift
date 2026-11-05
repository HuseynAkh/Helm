// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Pure F-055 sheet adapter; all validation and basename handling stay in Core (B-046/B-047).
public struct BatchRenameViewModel: Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case addText = "Add Text", findReplace = "Find & Replace", template = "Template"
    }
    public var mode: Mode = .addText { didSet { cache = BatchRenameEvaluationCache() } }
    public var prepend: String = "" { didSet { cache = BatchRenameEvaluationCache() } }
    public var append: String = "" { didSet { cache = BatchRenameEvaluationCache() } }
    public var find: String = "" { didSet { cache = BatchRenameEvaluationCache() } }
    public var replacement: String = "" { didSet { cache = BatchRenameEvaluationCache() } }
    public var template: String = "[Original Name]-[Counter]" { didSet { cache = BatchRenameEvaluationCache() } }
    public var counterStart: String = "1" { didSet { cache = BatchRenameEvaluationCache() } }
    public let items: [URL]
    private let existingNames: [URL: Set<String>]
    private let caseSensitive: Bool
    private let date: Date
    private let timeZone: TimeZone
    public init(items: [URL], existingNames: [URL: Set<String>], caseSensitive: Bool,
                date: Date, timeZone: TimeZone) {
        self.items = items; self.existingNames = existingNames; self.caseSensitive = caseSensitive
        self.date = date; self.timeZone = timeZone
    }
    private var cache = BatchRenameEvaluationCache()
    var revision: UUID { cache.id }
    var evaluationCount: Int { cache.count }
    var evaluation: BatchRenameEvaluation { cache.value { makeEvaluation(plan: makePlan()) } }
    func cancellableEvaluation() throws -> BatchRenameEvaluation {
        try Task.checkCancellation()
        return try cache.value {
            let plan = try makePlan(cancellationCheck: { try Task.checkCancellation() })
            try Task.checkCancellation()
            let evaluation = makeEvaluation(plan: plan)
            try Task.checkCancellation()
            return evaluation
        }
    }
    public var plan: BatchRenamePlan? { evaluation.plan }
    private func makePlan() -> BatchRenamePlan? {
        // The compatibility path has no cancellation hook; rule errors are plan issues.
        try? makePlan(cancellationCheck: {})
    }
    private func makePlan(cancellationCheck: () throws -> Void) throws -> BatchRenamePlan? {
        let rule: BatchRenameRule
        switch mode {
        case .addText: rule = .addText(prepend: prepend, append: append)
        case .findReplace: rule = .findReplace(find: find, replacement: replacement)
        case .template:
            guard let start = Int(counterStart) else { return nil }
            rule = .template(template, counterStart: start)
        }
        return try BatchRenamePlanner.plan(items: items, rule: rule, existingNames: existingNames,
                                      caseSensitive: caseSensitive, date: date, timeZone: timeZone, cancellationCheck: cancellationCheck)
    }
    public var preview: [RenamePreview] { evaluation.preview }
    public var canRename: Bool { evaluation.plan?.canExecute == true }
    public var validationMessages: [String] { evaluation.messages }
    private func makeEvaluation(plan: BatchRenamePlan?) -> BatchRenameEvaluation {
        guard let plan else {
            return BatchRenameEvaluation(revision: revision, plan: nil, messages: ["Enter a whole number for Start at."])
        }
        var messages = plan.issues.prefix(20).map { issue in
            switch issue {
            case let .invalidName(url, error): return "\(url.lastPathComponent): \(NewItemNameValidation.message(for: error))"
            case let .counterOverflow(url): return "\(url.lastPathComponent): Counter is too large."
            case let .duplicateSource(url): return "Item selected more than once: \(url.path)"
            case let .overlappingSources(ancestor, descendant):
                return "A folder and an item inside it cannot be renamed in the same batch: \(ancestor.path) and \(descendant.path)."
            case let .collision(url): return "An item named “\(url.lastPathComponent)” already exists in \(url.deletingLastPathComponent().path)."
            }
        }
        if plan.issues.count > 20 { messages.append("… and \(plan.issues.count - 20) more issues.") }
        return BatchRenameEvaluation(revision: revision, plan: plan, messages: messages)
    }
}
