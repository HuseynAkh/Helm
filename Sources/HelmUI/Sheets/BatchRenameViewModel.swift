// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Pure F-055 sheet adapter; all validation and basename handling stay in Core (B-046/B-047).
public struct BatchRenameViewModel: Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case addText = "Add Text", findReplace = "Find & Replace", template = "Template"
    }
    public var mode: Mode = .addText
    public var prepend: String = ""
    public var append: String = ""
    public var find: String = ""
    public var replacement: String = ""
    public var template: String = "[Original Name]-[Counter]"
    public var counterStart: String = "1"
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
    public var plan: BatchRenamePlan? {
        let rule: BatchRenameRule
        switch mode {
        case .addText: rule = .addText(prepend: prepend, append: append)
        case .findReplace: rule = .findReplace(find: find, replacement: replacement)
        case .template:
            guard let start = Int(counterStart) else { return nil }
            rule = .template(template, counterStart: start)
        }
        return BatchRenamePlanner.plan(items: items, rule: rule, existingNames: existingNames,
                                      caseSensitive: caseSensitive, date: date, timeZone: timeZone)
    }
    public var preview: [RenamePreview] { Array((plan?.previews ?? []).prefix(20)) }
    public var canRename: Bool { plan?.canExecute == true }
    public var validationMessages: [String] {
        guard let plan = plan else { return ["Enter a whole number for Start at."] }
        return plan.issues.map { issue in
            switch issue {
            case let .invalidName(url, error): return "\(url.lastPathComponent): \(NewItemNameValidation.message(for: error))"
            case let .counterOverflow(url): return "\(url.lastPathComponent): Counter is too large."
            case let .duplicateSource(url): return "Item selected more than once: \(url.path)"
            case let .collision(url): return "An item named “\(url.lastPathComponent)” already exists in \(url.deletingLastPathComponent().path)."
            }
        }
    }
}
